use test

-- A method infers a template parameter from a function argument. `T` is the parameter of the type.
type Box[T Any]:
    val T

fn (&Box[]) map(f fn(T) -> %U) -> Box[U]:
    return Box[U]{val=f(self.val)}

fn (&Box[]) zip(other %V, f fn(T, V) -> %U) -> U:
    return f(self.val, other)

fn name(x float) -> str:
    return 'v%{x}'

fn cat(a float, b str) -> str:
    return '%{a}%{b}'

b := Box[float]{val=1.5}
test.eq('v1.5', b.map(name).val)
test.eq(3.0, b.map(|x| x * 2).val)
test.eq('a1.5', b.map(|x| 'a%{x}').val)
test.eq(true, b.map(|x| x > 1.0).map(|x| !x).val == false)
test.eq('1.5z', b.zip('z', cat))
test.eq(3.5, b.zip(2, |x, y| x + float(y)))

-- A method of a type that is not a template.
type Num:
    n int

fn (&Num) with(f fn(int) -> %U) -> U:
    return f(self.n)

fn inc(x int) -> int:
    return x + 1

n := Num{n=3}
test.eq(4, n.with(inc))
test.eq(4, n.with(|x| x + 1))
test.eq('n3', n.with(|x| 'n%{x}'))

--cytest: pass