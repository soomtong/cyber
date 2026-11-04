use t 'test'

--| Tests sensitive to line numbers.
-- -- stackTrace(), current frame.
-- t.eq(stackTrace(), '''main:6:5 main:
--     throw error.Boom
--     ^
-- ''')

-- -- stackTrace(), one frame before and one frame after.
-- fn foo2():
--     stackTrace()
--     t.eq(errorReport(), '''main:15:5 foo2:
--     throw error.Boom
--     ^
-- main:18:9 foo:
--         foo2()
--         ^
-- main:30:1 main:
-- foo()
-- ^
-- ''')
-- fn foo():
--     foo2()
-- foo()

-- error(), see error_test.cy

-- to_print_string()
t.eq(to_print_string(123), '123')
t.eq(to_print_string('abc'), 'abc')

-- to_print_string(), structs render as a record literal with the type name.
type Point:
    x int
    y int
type Named:
    name str
    tag  ?str
    xs   []int
type Tup struct(a int, b str)
t.eq(to_print_string(Point{x=1, y=2}), 'Point{x=1, y=2}')
t.eq(to_print_string(Named{name='rex', tag=none, xs=[]int{1, 2}}), "Named{name='rex', tag=none, xs={1, 2}}")
t.eq(to_print_string(Named{name='rex', tag='t', xs=[]int{}}), "Named{name='rex', tag='t', xs={}}")
t.eq(to_print_string(Tup{1, 'x'}), "Tup{a=1, b='x'}")
t.eq('%{Point{x=3, y=4}}', 'Point{x=3, y=4}')

-- to_print_string(), choices render as the case with its payload.
type Shape enum:
    case circle int
    case rect   Point
    case empty
t.eq(to_print_string(Shape.circle(5)), 'Shape.circle(5)')
t.eq(to_print_string(Shape.rect(Point{x=1, y=2})), 'Shape.rect(Point{x=1, y=2})')
t.eq(to_print_string(Shape.empty), 'Shape.empty')

-- to_print_string(), slices and vectors render their elements.
t.eq(to_print_string([]int{1, 2, 3}), '{1, 2, 3}')
t.eq(to_print_string([]str{'a', 'b'}), "{'a', 'b'}")
t.eq(to_print_string([3]int{1, 2, 3}), '{1, 2, 3}')
t.eq(to_print_string([](?int){1, none}), '{1, none}')
t.eq(to_print_string([]Point{Point{x=1, y=2}}), '{Point{x=1, y=2}}')

--cytest: pass