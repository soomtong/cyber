use meta
use test

type Foo:
    a int = 123
    b int

foo := Foo{b=321}
test.eq(123, foo.a)
test.eq(321, foo.b)

-- Array, Map
type Foo2:
    a int   = 0
    b Array[int] = {}
    c Map[str, int] = {}
foo2 := Foo2{}
test.eq(0, foo2.a)
test.eq(0, foo2.b.len())
test.eq(0, foo2.c.size())

-- A default value names the struct's declarations, not the locals where the literal is written.
const K = 7
type Bar:
    x int = K
fn bar_x() -> int:
    K := 100
    bar := Bar{}
    return bar.x + K
test.eq(107, bar_x())

-- A template parameter in a default value.
type Box[T Any]:
    v T = T(3)
    n int = type.size(T)
box := Box[int]{}
test.eq(3, box.v)
test.eq(8, box.n)

-- A compile-time literal.
type Lit:
    x int = K * 2
fn lit_x() -> int:
    #lit := Lit{}
    return #{lit.x}
test.eq(14, lit_x())

-- `meta.has_field_default` and `meta.field_default`.
test.eq(true, #{meta.has_field_default(Bar, 'x')})
test.eq(false, #{meta.has_field_default(Foo, 'b')})
test.eq(7, meta.field_default(Bar, 'x'))
test.eq(0, meta.field_default(Foo2, 'b').len())

-- A default that reads a global is copied for each literal, as an explicit `G2{s=G}` is.
global G str = 'hello' + ' world'
type G2:
    s str = G
for 0..3:
    g2 := G2{}
    test.eq('hello world', g2.s)
g2a := G2{}
g2b := G2{}
test.eq('hello world', g2a.s)
test.eq('hello world', g2b.s)
test.eq('hello world', meta.field_default(G2, 's'))
test.eq('hello world', G)

--cytest: pass