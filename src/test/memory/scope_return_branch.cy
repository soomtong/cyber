use test

-- A `scope` function returns a borrow from its `scope` parameter on every branch, also in a value that holds one.

type Holder:
    r &int

type Foo:
    a int
    b int

fn by_if(scope p &[]int, k int) -> scope &int:
    return if (k == 0) &p[0] else &p[1]

fn by_switch(scope p &[]int, k int) -> scope &int:
    return switch k:
        case 0 => &p[0]
        else => &p[1]

fn by_local(scope p &[]int, k int) -> scope &int:
    r := if (k == 0) &p[0] else &p[1]
    return r

fn by_opt(scope p &[]int, k int) -> scope ?&int:
    if k < 0: return none
    return &p[k]

fn by_res(scope p &[]int, k int) -> scope !&int:
    if k < 0: return error.Oops
    return &p[k]

fn by_holder(scope p &[]int, k int) -> scope Holder:
    return Holder{r=&p[k]}

fn first(scope p &[]int, k int) -> scope &int:
    return &p[0]

fn read(x &int) -> int:
    return x.*

-- An argument that the result does not borrow from can borrow a local.
fn by_call(scope p &[]int, k int) -> scope &int:
    y := 3
    return first(p, read(if (k == 0) &y else &p[1]))

fn (scope &Foo) pick(k int) -> scope &int:
    return if (k == 0) &self.a else &self.b

a := []int{1, 2}
test.eq(2, by_if(&a, 1).*)
test.eq(1, by_switch(&a, 0).*)
test.eq(2, by_local(&a, 1).*)
test.eq(2, by_opt(&a, 1).?.*)
test.eq(2, by_res(&a, 1)!.*)
test.eq(2, by_holder(&a, 1).r.*)
test.eq(1, by_call(&a, 0).*)
f := Foo{a=5, b=6}
test.eq(6, f.pick(1).*)

--cytest: pass
