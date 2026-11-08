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

--cytest: pass
