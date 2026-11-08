use test

-- Partial moves of managed members (`str`, nested structs). See `docs/decisions/project_partial_move.md`.

global deinits int = 0

type Res:
    name str
fn (&Res) @deinit():
    deinits += 1

type Foo:
    a int
    b str

type Inner:
    s str
    t str
    n int

type Outer:
    inner Inner
    x str
    k int

type Pair:
    a Res
    b Res
    c str

-- Move a `str` member. The other members stay accessible.
f := Foo{a=123, b='abc'}
b := move f.b
test.eq('abc', b)
test.eq(123, f.a)

-- Move a member of a nested struct member. Its siblings and the outer members stay accessible.
o := Outer{inner=Inner{s='s', t='t', n=1}, x='x', k=2}
s := move o.inner.s
test.eq('s', s)
test.eq('t', o.inner.t)
test.eq(1, o.inner.n)
test.eq('x', o.x)
test.eq(2, o.k)

-- Move a whole nested struct member.
o2 := Outer{inner=Inner{s='s', t='t', n=1}, x='x', k=2}
inner := move o2.inner
test.eq('s', inner.s)
test.eq('t', inner.t)
test.eq('x', o2.x)

-- A member with `@deinit` is moved as a whole. The moved member is destructed by its new owner only.
fn move_pair():
    p := Pair{a=Res{name='a'}, b=Res{name='b'}, c='c'}
    a := move p.a
    test.eq('a', a.name)
    test.eq('b', p.b.name)
    test.eq('c', p.c)
move_pair()
test.eq(2, deinits)

-- Reassigning a partially moved variable makes it whole again.
deinits = 0
fn reassign_pair():
    p := Pair{a=Res{name='a'}, b=Res{name='b'}, c='c'}
    a := move p.a
    p = Pair{a=Res{name='a2'}, b=Res{name='b2'}, c='c2'}
    test.eq('a2', p.a.name)
    test.eq('a', a.name)
reassign_pair()
test.eq(4, deinits)

-- Assigning to a moved member revives it. The old value belongs to its new owner and is not destructed again.
deinits = 0
fn revive_pair():
    p := Pair{a=Res{name='a'}, b=Res{name='b'}, c='c'}
    a := move p.a
    p.a = Res{name='a2'}
    test.eq('a2', p.a.name)
    test.eq('a', a.name)
    -- Every member is alive again, so the value can be used as a whole.
    q := move p
    test.eq('a2', q.a.name)
    test.eq('b', q.b.name)
revive_pair()
test.eq(3, deinits)

-- Revive a `str` member and a non-managed member.
f2 := Foo{a=1, b='abc'}
n := move f2.a
b2 := move f2.b
f2.a = 5
f2.b = 'xyz'
test.eq(5, f2.a)
test.eq('xyz', f2.b)
g := f2
test.eq('xyz', g.b)

-- Revive a member of a nested struct member.
o3 := Outer{inner=Inner{s='s', t='t', n=1}, x='x', k=2}
s3 := move o3.inner.s
o3.inner.s = 's2'
test.eq('s2', o3.inner.s)
inner3 := o3.inner
test.eq('s2', inner3.s)

-- Reassign a nested struct member while one of its members is moved out. Only its members that are still alive are destructed.
o4 := Outer{inner=Inner{s='s', t='tttttttttttttttttttttttttttttttttttttttttttt', n=1}, x='x', k=2}
s4 := move o4.inner.s
o4.inner = Inner{s='S', t='T', n=9}
test.eq('S', o4.inner.s)
test.eq('T', o4.inner.t)
test.eq('s', s4)

-- Members of a `@deinit` member share its single state. Reading one after a sibling was moved is fine.
type Two:
    a Res
    b Res
fn read_sibling():
    t := Two{a=Res{name='a'}, b=Res{name='b'}}
    b := move t.b
    test.eq('a', t.a.name)
    name := t.a.name
    test.eq('a', name)
    t.a.name = 'a2'
    test.eq('a2', t.a.name)
read_sibling()

--cytest: pass
