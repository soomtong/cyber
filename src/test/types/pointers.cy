use test

-- Read dereferenced `int`.
a := 123
b := *a
test.eq(123, b.*)

-- pointer indexing, primitive.
test.eq(123, b[0])

-- pointer set index, primitive.
b[0] = 234
test.eq(234, b[0])
test.eq(234, a)

-- pointer slicing
test.eq(10, b[0..10].len())

-- Write to `int` pointer.
b.* = 345
test.eq(345, b.*)
test.eq(345, a)

type Foo cstruct:
    a int

-- Read dereferenced cstruct.
f := Foo{a=123}
g := *f
test.eq(123, g.a)
test.eq(123, g.*.a)

-- pointer indexing, cstruct.
test.eq(123, g[0].a)

-- pointer set index, cstruct.
g[0] = Foo{a=234}
test.eq(g[0].a, 234)
test.eq(234, f.a)

-- Write to cstruct pointer.
g.* = Foo{a=345}
test.eq(345, g.a)

-- Write to cstruct pointer member.
g.a = 456
test.eq(456, g.a)

-- Read dereferenced `int` from static variable.
global sa int = 123
b2 := *sa
test.eq(123, b2.*)

-- Cast to Ptr.
ptr := as[Ptr[void]] 0xDEADBEEF
test.eq(3735928559, as ptr)

-- Reference to pointer.
a2 := 123
a2_ref := ^a2
a2_ptr := as[Ptr[int]] a2_ref
test.eq(123, a2_ptr.*)

-- Pointer span of array.
arr := [2]Foo{
    {a=123},
    {a=234},
}
foo_span := arr[0..]
test.eq(2, foo_span.len())
test.eq(123, foo_span[0].a)
test.eq(234, foo_span[1].a)

-- Address of an indexed element through a pointer expression that is not addressable
-- (a bitcast) refers to the element itself, not to a copy of it.
type Named:
    name str
    n    int
named := Named{name='abc', n=1}
named_addr := as[int] *named
np := *(as[Ptr[Named]] named_addr)[0]
test.eq(named_addr, as[int] np)
np.n = 2
test.eq(2, named.n)
test.eq('abc', np.name)

--cytest: pass