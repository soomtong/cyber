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

-- to_print_string(), a borrowed Map or Array renders its entries, other borrows render the value.
m := Map[str, int]{}
m['a'] = 1
t.eq(to_print_string(&m), "{'a': 1}")
t.eq('%{&m}', "{'a': 1}")
t.eq(to_print_string(&Map[str, int]{}), '{}')
arr := Array[int]{}
arr << 1
arr << 2
t.eq(to_print_string(&arr), '{1, 2}')
t.eq(to_print_string(&Array[str]{}), '{}')
store := ArrayStore[int]{}
store << 7
t.eq(to_print_string(&store), '{7}')
pt := Point{x=1, y=2}
t.eq(to_print_string(&pt), 'Point{x=1, y=2}')

-- dump_str(), scalars render like print and strings keep their quotes.
t.eq(dump_str(123), '123')
t.eq(dump_str('abc'), "'abc'")
t.eq(dump_str(true), 'true')
t.eq(dump_str(error.Foo), 'error.Foo')
t.eq(dump_str(?int(3)), '3')
t.eq(dump_str(?int(none)), 'none')

-- dump_str(), structs put each field on its own line with the field value.
t.eq(dump_str(Point{x=1, y=2}), 'Point{\n  x: 1\n  y: 2\n}')
t.eq(dump_str(Tup{1, 'x'}), "Tup{\n  a: 1\n  b: 'x'\n}")
t.eq(dump_str(Named{name='rex', tag=none, xs=[]int{1, 2}}), "Named{\n  name: 'rex'\n  tag: none\n  xs: []int{\n    1\n    2\n  }\n}")
t.eq(dump_str(Named{name='rex', tag='t', xs=[]int{}}), "Named{\n  name: 'rex'\n  tag: 't'\n  xs: []int{}\n}")

-- dump_str(), choices and enums render as the case, payloads nest with the current indent.
t.eq(dump_str(Shape.circle(5)), 'Shape.circle(5)')
t.eq(dump_str(Shape.rect(Point{x=1, y=2})), 'Shape.rect(Point{\n  x: 1\n  y: 2\n})')
t.eq(dump_str(Shape.empty), 'Shape.empty')
type Color enum:
    case red
    case blue
t.eq(dump_str(Color.red), 'Color.red')

-- dump_str(), slices and vectors carry their type name and one element per line.
t.eq(dump_str([]str{'a', 'b'}), "[]str{\n  'a'\n  'b'\n}")
t.eq(dump_str([](?int){1, none}), '[]?int{\n  1\n  none\n}')
t.eq(dump_str([3]int{1, 2, 3}), '[3]int{\n  1\n  2\n  3\n}')
t.eq(dump_str([0]int{}), '[0]int{}')
t.eq(dump_str([]Point{Point{x=1, y=2}}), '[]Point{\n  Point{\n    x: 1\n    y: 2\n  }\n}')

-- dump_str(), references render as their type name.
t.eq(dump_str(^Point{x=1, y=2}), '^Point')

-- dump_str(), a borrowed Map or Array carries its type name, other borrows dump the value.
t.eq(dump_str(&m), "Map[str, int]{\n  'a': 1\n}")
t.eq(dump_str(&Map[str, int]{}), 'Map[str, int]{}')
t.eq(dump_str(&arr), 'Array[int]{\n  1\n  2\n}')
t.eq(dump_str(&Array[str]{}), 'Array[str]{}')
t.eq(dump_str(&store), 'ArrayStore[int]{\n  7\n}')
t.eq(dump_str(&pt), 'Point{\n  x: 1\n  y: 2\n}')

--cytest: pass