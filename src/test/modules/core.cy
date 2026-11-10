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

-- assert()
assert(true)
assert(1 + 1 == 2)
assert(3, 1 + 2)
assert('ab', 'a' + 'b')

-- min(), max()
t.eq(min(1, 2), 1)
t.eq(min(2, 1), 1)
t.eq(min(-3, -3), -3)
t.eq(max(1, 2), 2)
t.eq(max(2, 1), 2)
t.eq(min(1.5, -2.5), -2.5)
t.eq(max(1.5, -2.5), 1.5)
t.eq(min(byte(3), byte(200)), byte(3))
t.eq(max(byte(3), byte(200)), byte(200))

-- binary_search()
fn search(xs &[]int, needle int) -> ?int:
    res := binary_search(xs.len(), needle, &|n, idx|):
        if n < xs[idx]:
            return .lt
        else n > xs[idx]:
            return .gt
        else:
            return .eq
    return res
sorted := []int{1, 3, 5, 7, 9}
t.eq(search(&sorted, 1).?, 0)
t.eq(search(&sorted, 5).?, 2)
t.eq(search(&sorted, 9).?, 4)
t.eq(search(&sorted, 0), none)
t.eq(search(&sorted, 4), none)
t.eq(search(&sorted, 10), none)
t.eq(search(&[]int{}, 5), none)
t.eq(search(&[]int{5}, 5).?, 0)

-- binary_search_lower()
fn search_lower(xs &[]int, needle int) -> int:
    res := binary_search_lower(xs.len(), needle, &|n, idx|):
        if n < xs[idx]:
            return .lt
        else n > xs[idx]:
            return .gt
        else:
            return .eq
    return res
t.eq(search_lower(&sorted, 0), 0)
t.eq(search_lower(&sorted, 1), 0)
t.eq(search_lower(&sorted, 4), 2)
t.eq(search_lower(&sorted, 5), 2)
t.eq(search_lower(&sorted, 9), 4)
t.eq(search_lower(&sorted, 10), 5)
t.eq(search_lower(&[]int{}, 5), 0)
-- With duplicates, the lowest matching index is returned.
t.eq(search_lower(&[]int{1, 2, 2, 2, 3}, 2), 1)

-- str.compare()
t.eq('abc'.compare('abc'), CompareOrder.eq)
t.eq('abc'.compare('abd'), CompareOrder.lt)
t.eq('abd'.compare('abc'), CompareOrder.gt)
t.eq('ab'.compare('abc'), CompareOrder.lt)
t.eq('abc'.compare('ab'), CompareOrder.gt)
t.eq(''.compare(''), CompareOrder.eq)

-- Int unsigned comparisons.
t.eq((-1).ult(1), false)
t.eq(1.ult(-1), true)
t.eq(1.ult(1), false)
t.eq(1.ule(1), true)
t.eq((-1).ule(1), false)
t.eq((-1).ugt(1), true)
t.eq(1.ugt(1), false)
t.eq(1.uge(1), true)
t.eq(1.uge(-1), false)

-- Int unsigned arithmetic.
t.eq((-1).udiv(2), int.max)
t.eq(7.udiv(2), 3)
t.eq((-1).umod(16), 15)
t.eq(7.umod(4), 3)
t.eq(3.umul(4), 12)
t.eq((-1).umul(2), -2)

-- Int.asr() keeps the sign, `>>` shifts in zeros.
t.eq((-8).asr(1), -4)
t.eq(-8 >> 1, int.max - 3)
t.eq((-17).asr(2), -5)
t.eq(8.asr(2), 2)
t.eq((-8).asr(0), -8)
t.eq((-1).asr(63), -1)
t.eq(int.min.asr(63), -1)
t.eq(int.max.asr(62), 1)

-- Int.asr(), an amount past the sign bit leaves only the sign.
t.eq((-8).asr(64), -1)
t.eq(8.asr(200), 0)

-- Int.asr(), narrow ints shift from their own sign bit.
t.eq(i8(-8).asr(i8(1)), i8(-4))
t.eq(i8(100).asr(i8(2)), i8(25))
t.eq((i8(100) + i8(100)).asr(i8(1)), i8(-28))
t.eq(i16(-8).asr(i16(2)), i16(-2))
t.eq(i32(-8).asr(i32(1)), i32(-4))
t.eq(i32.min.asr(i32(31)), i32(-1))

-- Int.asr(), the result can be assigned over either operand.
asr_x := -1024
asr_n := 3
asr_x = asr_x.asr(asr_n)
t.eq(asr_x, -128)
asr_n = asr_x.asr(asr_n)
t.eq(asr_n, -16)

-- Int.unsigned(), the source bits are zero extended or kept as is.
t.eq(int.unsigned(i8(-1)), 255)
t.eq(int.unsigned(i32(-1)), 0xFFFFFFFF)
t.eq(int.unsigned(true), 1)
t.eq(int.unsigned(false), 0)
t.eq(i8.unsigned(255), i8(-1))
t.eq(int(i8(-1)), -1)

-- Int.ufmt()
t.eq(123.ufmt(), '123')
t.eq((-1).ufmt(), '18446744073709551615')
t.eq((-1).ufmt(.hex), '0xffffffffffffffff')
t.eq(5.ufmt(.bin), '0b101')
t.eq(8.ufmt(.oct), '0o10')

-- Raw.fmt() defaults to hex.
t.eq(r32(255).fmt(), '0xff')

-- Raw.zero, Raw.ones
t.eq(byte.zero, byte(0))
t.eq(byte.ones, byte(255))
t.eq(r16.ones, r16(0xFFFF))

-- Buffer
buf := Buffer[int](4)
t.eq(buf.len(), 0)
t.eq(buf.cap(), 4)
buf << 1
buf << 2
buf << 3
t.eq(buf.len(), 3)
t.eq(buf[0], 1)
t.eq(buf.last(), 3)
sum := 0
for buf |x|:
    sum += x
t.eq(sum, 6)
t.eq(buf[1..].len(), 2)
buf.size_down(1)
t.eq(buf.len(), 1)

--cytest: pass