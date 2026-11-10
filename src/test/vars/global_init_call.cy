use t 'test'
use lib '../modules/test_mods/ginit.cy'

-- An initializer can call a function that reads a global declared before it.
global base int = 7
global from_base int = add_base(1)
fn add_base(x int) -> int:
    return base + x
t.eq(8, from_base)

-- A function can write an earlier global. Initializers run in declaration order.
global count int = 0
global first int = next()
global second int = next()
fn next() -> int:
    count += 1
    return count
t.eq(1, first)
t.eq(2, second)
t.eq(2, count)

-- A function value is not called by the initializer that stores it. It can read a later global.
type Getter = fn() -> int
global getter Getter = fn() -> int:
    return late
global late int = 5
t.eq(5, getter())

-- Creating a generator does not run its body. The body can read the global that holds it.
#[generator]
fn counter() -> int:
    t.eq(gen.status(), .running)
    yield 1
type CounterFn = fn() -> int
global gen ^Generator[CounterFn] = counter()
t.eq(1, gen.next().?)

-- An indirect call can reach every function that is used as a value. The function values above read
-- globals that are declared before this point.

-- `scale` is read by a trait method below. A trait method counts as a function value, so it is declared here.
global scale int = 3

-- A callback that reads an earlier global.
global bias int = 10
global smallest int = find_smallest()
fn find_smallest() -> int:
    arr := []int{3, 1, 2}
    arr.sort(|x, y| x + bias < y + bias)
    return arr[0]
t.eq(1, smallest)

-- A trait method that reads an earlier global.
type Shape trait:
    fn area() -> int
type Square:
    with Shape
    side int
fn (&Square) area() -> int:
    return self.side * scale
fn make_area() -> int:
    var shape ^Dyn[Shape] = ^Square{side=2}
    return shape.area()
global area int = make_area()
t.eq(6, area)

-- The globals of an imported module are initialized before the globals of the importer.
global from_lib int = lib.next_id()
global from_lib_str str = lib.label()
t.eq(101, from_lib)
t.eq('LIB!', from_lib_str)
t.eq(101, lib.last_id)

--cytest: pass
