use test

-- An inline function type uses the template parameters that are known from the earlier arguments.
fn filter(items []%T, f fn(T) -> bool) -> []T:
    out := []T{}
    for items |it|:
        if f(it):
            out += it
    return out

fn fold(items []%T, init T, f fn(T, T) -> T) -> T:
    acc := init
    for items |it|:
        acc = f(acc, it)
    return acc

fn map(%U type, items []%T, f fn(T) -> U) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out

fn is_even(x int) -> bool:
    return x % 2 == 0

big := filter([]float{1.0, 4.0, 5.0}, |x| x > 3.0)
test.eq(2, big.len())
test.eq(4.0, big[0])
test.eq(5.0, big[1])

even := filter([]int{1, 2, 3, 4}, is_even)
test.eq(2, even.len())
test.eq(4, even[1])

test.eq(6, fold([]int{1, 2, 3}, 0, |a, b| a + b))
test.eq('abc', fold([]str{'a', 'b', 'c'}, '', |a, b| a + b))

strs := map(str, []int{1, 2}, |x| str(x) + '!')
test.eq('1!', strs[0])
test.eq('2!', strs[1])

-- A field and a method of a generic type.
type Lazy[T Any]:
    make fn() -> T

fn (&Lazy[]) then(f fn(T) -> T) -> T:
    return f(self.make())

fn one() -> int:
    return 1

lazy := Lazy[int]{make=one}
test.eq(11, lazy.then(|x| x + 10))

-- An alias and an inline type of the same variant are one type.
type PredFn[T Any] = fn(T) -> bool
var p PredFn[int] = is_even
test.eq(1, filter([]int{1, 2, 3}, p).len())

--cytest: pass