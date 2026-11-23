use test

-- A trait method with a body is a default method.
type Shape trait:
    fn area() -> float
    fn name() -> str

    -- Calls required methods. Returns a managed value.
    fn describe() -> str:
        return '%{self.name()} with area %{self.area()}'

    -- Calls another default method.
    fn shout(times int) -> str:
        res := self.describe()
        for 0..times:
            res += '!'
        return res

    fn is_big() -> bool:
        return self.area() > 10.0

type Circle:
    with Shape
    radius float

fn (&Circle) area() -> float:
    return 3.0 * self.radius * self.radius

fn (&Circle) name() -> str:
    return 'circle'

-- Overrides a default method.
type Square:
    with Shape
    width float

fn (&Square) area() -> float:
    return self.width * self.width

fn (&Square) name() -> str:
    return 'square'

fn (&Square) describe() -> str:
    return 'a square of %{self.width}'

-- Direct calls on the implementing type.
c := Circle{radius=2}
test.eq('circle with area 12.0', c.describe())
test.eq('circle with area 12.0!!', c.shout(2))
test.eq(true, c.is_big())
test.eq('circle with area 3.0', Circle{radius=1}.describe())
test.eq(false, Circle{radius=1}.is_big())

sq := Square{width=2}
test.eq('a square of 2.0', sq.describe())
-- A default method reaches the override.
test.eq('a square of 2.0!', sq.shout(1))
test.eq(false, sq.is_big())

-- Through a `^Dyn` reference.
var s ^Dyn[Shape] = ^Circle{radius=2}
test.eq('circle with area 12.0', s.describe())
test.eq('circle with area 12.0!!!', s.shout(3))
test.eq(true, s.is_big())
s = ^Square{width=4}
test.eq('a square of 4.0', s.describe())
test.eq('a square of 4.0!', s.shout(1))
test.eq(true, s.is_big())

-- Through a `&Dyn` borrow.
fn describe_twice(shape &Dyn[Shape]) -> str:
    return shape.describe() + ', ' + shape.describe()
test.eq('circle with area 12.0, circle with area 12.0', describe_twice(&c))
test.eq('a square of 2.0, a square of 2.0', describe_twice(&sq))

-- Through a template parameter.
fn shout_once(shape &%T) -> str:
    return shape.shout(1)
test.eq('circle with area 12.0!', shout_once(&c))
test.eq('a square of 2.0!', shout_once(&sq))

-- In a container. The results are managed values.
shapes := []^Dyn[Shape]{^Circle{radius=1}, ^Square{width=3}}
lines := []str{}
for shapes |shape|:
    lines += shape.shout(1)
test.eq('circle with area 3.0!, a square of 3.0!', lines.join(', '))

-- `self` is the trait view of the receiver. It can be passed on.
type Named trait:
    fn name() -> str
    fn greet(greeting str) -> str:
        return greeting + ', ' + name_of(self) + '!'

fn name_of(named &Dyn[Named]) -> str:
    return named.name()

-- A template type gets the default method.
type Box[T Any]:
    with Named
    inner T

fn (&Box[]) name() -> str:
    return 'box of %{self.inner}'

test.eq('hi, box of 3!', Box[int]{inner=3}.greet('hi'))
var named ^Dyn[Named] = ^Box[str]{inner='abc'}
test.eq('yo, box of abc!', named.greet('yo'))

-- A template type overrides the default method.
type Quiet[T Any]:
    with Named
    inner T

fn (&Quiet[]) name() -> str:
    return 'quiet'

fn (&Quiet[]) greet(greeting str) -> str:
    return '...'

test.eq('...', Quiet[int]{inner=1}.greet('hi'))
named = ^Quiet[int]{inner=1}
test.eq('...', named.greet('hi'))

-- A default method of a generic trait sees the template parameter.
type Source[T Any] trait:
    fn get() -> T
    fn pair() -> []T:
        var first T = self.get()
        return []T{first, self.get()}

type One:
    with Source[int]

fn (&One) get() -> int:
    return 1

type Word:
    with Source[str]
    word str

fn (&Word) get() -> str:
    return self.word + '.'

test.eq('{1, 1}', '%{One{}.pair()}')
test.eq('ab., ab.', Word{word='ab'}.pair().join(', '))
var src ^Dyn[Source[str]] = ^Word{word='cd'}
test.eq('cd., cd.', src.pair().join(', '))

-- Two traits with a default method of the same name. The type declares the method.
type Left trait:
    fn side() -> str:
        return 'left'

type Right trait:
    fn side() -> str:
        return 'right'

type Both:
    with Left
    with Right

fn (&Both) side() -> str:
    return 'both'

type OnlyLeft:
    with Left

test.eq('both', Both{}.side())
var left ^Dyn[Left] = ^Both{}
var right ^Dyn[Right] = ^Both{}
test.eq('both', left.side())
test.eq('both', right.side())
left = ^OnlyLeft{}
test.eq('left', left.side())
test.eq('left', OnlyLeft{}.side())

-- A trait with only default methods, and a default method that calls itself.
type Counter trait:
    fn count(n int) -> int:
        if n <= 0:
            return 0
        return 1 + self.count(n - 1)

type Unit:
    with Counter

test.eq(5, Unit{}.count(5))

--cytest: pass
