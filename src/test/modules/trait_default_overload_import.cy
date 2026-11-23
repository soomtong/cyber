use test
use td 'test_mods/trait_default.cy'
use impl 'test_mods/trait_default_impl.cy'
use ca 'test_mods/trait_default_cycle_a.cy'
use cb 'test_mods/trait_default_cycle_b.cy'

-- The trait is declared in a module, the type that gets its default overloads is declared here.
type A:
    with td.Show
    n int

fn (&A) show(indent int) -> str:
    return 'A%{self.n}@%{indent}'

a := A{n=1}
test.eq('A1@0', a.show())
test.eq('A1@3', a.show(3))
test.eq('A1@5', a.show(2, 3))

var show ^Dyn[td.Show] = ^A{n=2}
test.eq('A2@0', show.show())
test.eq('A2@9', show.show(4, 5))
test.eq('A1@0|A1@3', td.via(&a))

-- Every overload is a default method of the module. The type declares one of them.
type B:
    with td.Tag

type C:
    with td.Tag

fn (&C) tag() -> str:
    return 'c:' + self.tag(7)

test.eq('tag1', B{}.tag())
test.eq('tag2', B{}.tag(2))
test.eq('c:tag7', C{}.tag())
test.eq('tag3', C{}.tag(3))
var tag ^Dyn[td.Tag] = ^C{}
test.eq('c:tag7', tag.tag())
test.eq('tag4', tag.tag(4))

-- The trait and the type are declared in the same module.
local := td.Local{n=3}
test.eq('local3@0', local.show())
test.eq('local3@4', local.show(4))
test.eq('local3@6', local.show(2, 4))
test.eq('local3@0|local3@3', td.via(&local))

-- The type is declared in a module that imports the trait from another module.
far := impl.Far{n=4}
test.eq('far4@0', far.show())
test.eq('far4@2', far.show(2))
test.eq('far4@3', far.show(1, 2))
test.eq('far4@0|far4@3', td.via(&far))
show = impl.far_dyn(5)
test.eq('far5@0', show.show())
test.eq('far5@7', show.show(3, 4))

far_tag := impl.FarTag{}
test.eq('far-tag1', far_tag.tag())
test.eq('far-tag6', far_tag.tag(6))
tag = ^impl.FarTag{}
test.eq('far-tag1', tag.tag())

both := impl.FarBoth{}
test.eq('both@0', both.show())
test.eq('both@3', both.show(1, 2))
test.eq('tag1', both.tag())
test.eq('tag8', both.tag(8))

-- A template type of this module with a trait of the module.
type Box[T Any]:
    with td.Show
    inner T

fn (&Box[]) show(indent int) -> str:
    return 'box@%{indent}'

test.eq('box@0', Box[int]{inner=1}.show())
test.eq('box@5', Box[str]{inner='a'}.show(2, 3))

-- The module of the trait and the module of the type import each other.
sq := ca.make(2)
test.eq(4, sq.area())
test.eq(12, sq.area(3))
test.eq(24, sq.area(2, 3))
test.eq(28, ca.total(&sq))
var shape ^Dyn[ca.Shape] = cb.as_dyn(3)
test.eq(9, shape.area())
test.eq(54, shape.area(2, 3))

-- A type of this file with the trait of that pair of modules.
type Rect:
    with ca.Shape
    w int
    h int

fn (&Rect) area(scale int) -> int:
    return self.w * self.h * scale

rect := Rect{w=2, h=5}
test.eq(10, rect.area())
test.eq(70, ca.total(&rect))

--cytest: pass
