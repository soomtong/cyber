use p 'test_mods/priv.cy'
use meta
use test

-- Printing, interpolation and `==` read every field of a value through `meta.access`.
-- A private field does not stop them: metaprogramming is not checked for visibility.
type Vec2:
    x int
    -secret int

v := Vec2{x=1, secret=2}
test.eq('%{v}', 'Vec2{x=1, secret=2}')
test.eq(v == Vec2{x=1, secret=2}, true)
test.eq(v == Vec2{x=1, secret=3}, false)

-- A type of another module with a private field.
i := p.Info{a=3}
j := p.Info{a=3}
test.eq('%{i}', 'Info{a=3, b=0}')
test.eq(i == j, true)
test.eq(meta.access(i, 'b'), 0)

--cytest: pass
