use test

-- A default method next to a required overload with the same name.
type Fmt trait:
    fn show() -> str:
        return self.show(0)
    fn show(indent int) -> str

type A:
    with Fmt
    n int

fn (&A) show(indent int) -> str:
    return 'A%{self.n}@%{indent}'

a := A{n=1}
test.eq('A1@0', a.show())
test.eq('A1@3', a.show(3))

var fmt ^Dyn[Fmt] = ^A{n=2}
test.eq('A2@0', fmt.show())
test.eq('A2@5', fmt.show(5))

-- Every overload is a default method. The body of one calls another.
type Show trait:
    fn show() -> str:
        return self.show(0)
    fn show(indent int) -> str:
        return 'show@%{indent}'
    fn show(a int, b int) -> str:
        return self.show(a + b)

type AllDefault:
    with Show

all := AllDefault{}
test.eq('show@0', all.show())
test.eq('show@3', all.show(3))
test.eq('show@5', all.show(2, 3))

-- The type declares one of the default overloads and gets the others. The defaults reach the declared one.
type Mid:
    with Show
    n int

fn (&Mid) show(indent int) -> str:
    return 'mid%{self.n}@%{indent}'

mid := Mid{n=1}
test.eq('mid1@0', mid.show())
test.eq('mid1@3', mid.show(3))
test.eq('mid1@5', mid.show(2, 3))

type First:
    with Show

fn (&First) show() -> str:
    return 'first:' + self.show(7)

first := First{}
test.eq('first:show@7', first.show())
test.eq('show@1', first.show(1))
test.eq('show@3', first.show(1, 2))

-- Through `Dyn`.
var show ^Dyn[Show] = ^Mid{n=2}
test.eq('mid2@0', show.show())
test.eq('mid2@9', show.show(4, 5))
show = ^First{}
test.eq('first:show@7', show.show())
test.eq('show@9', show.show(4, 5))

fn via(s &Dyn[Show]) -> str:
    return s.show() + '|' + s.show(1)
test.eq('mid1@0|mid1@1', via(&mid))
test.eq('first:show@7|show@1', via(&first))
test.eq('show@0|show@1', via(&all))

-- An overload of the type that the trait does not have. Its parameters can name types that are declared later.
type Wide:
    with Fmt
    n int

fn (&Wide) show(indent int) -> str:
    return 'wide@%{indent}'

fn (&Wide) show(other Wide) -> str:
    return 'wide+%{other.n}'

fn (&Wide) show(later Later, list []Wide) -> str:
    return 'wide+later%{later.n}+%{list.len()}'

fn (&Wide) show(x %T, y T) -> str:
    return 'pair'

type Later:
    n int

wide := Wide{n=1}
test.eq('wide@0', wide.show())
test.eq('wide@2', wide.show(2))
test.eq('wide+3', wide.show(Wide{n=3}))
test.eq('wide+later4+0', wide.show(Later{n=4}, []Wide{}))
test.eq('pair', wide.show('a', 'b'))

-- A template type.
type Box[T Any]:
    with Fmt
    inner T

fn (&Box[]) show(indent int) -> str:
    return 'box@%{indent}'

test.eq('box@0', Box[int]{inner=1}.show())
test.eq('box@4', Box[int]{inner=1}.show(4))
fmt = ^Box[str]{inner='a'}
test.eq('box@0', fmt.show())

-- Two traits give a default method with the same name and other parameters.
type Left trait:
    fn side() -> str:
        return 'left'

type Right trait:
    fn side(n int) -> str:
        return 'right%{n}'

type Both:
    with Left
    with Right

both := Both{}
test.eq('left', both.side())
test.eq('right2', both.side(2))
var left ^Dyn[Left] = ^Both{}
var right ^Dyn[Right] = ^Both{}
test.eq('left', left.side())
test.eq('right3', right.side(3))

--cytest: pass
