use test

-- `xs = xs.appended(v)` where an argument can leave the statement (a failing `!` in a `try` or `scope` block, a
-- `break` or `continue` of an `?else:` block): the statement copies, as it did before the reuse of the buffer.
-- The local is unchanged where the jump arrives. See `docs/decisions/project_last_use.md` "B".

type S struct:
    xs []int

fn may(ok bool) -> !int:
    if !ok:
        return error.Nope
    return 2

fn pick(i int) -> ?int:
    if i == 2:
        return none
    return i

-- A failing `!` goes to the handler, which reads the local.
fn run(ok bool) -> int:
    xs := []int{1}
    try:
        xs = xs.appended(may(ok)!)
    else:
        return xs.len() + 10
    return xs.len()

-- The other methods, and a call around the method.
fn run2(ok bool) -> int:
    xs := []int{1, 2, 3}
    try:
        xs = xs.inserted(0, may(true)!)
        xs = xs.removed(may(true)! - 2)
        xs = xs + []int{may(true)!}
        xs = xs.appended(1).appended(may(ok)!)
        xs = xs.appended(9)
    else:
        return xs.len() + 10
    return xs.len()

-- A `scope` block.
fn run3(ok bool) -> !int:
    xs := []int{1}
    scope |s|:
        xs = xs.appended(may(ok)!)
    return xs.len()

-- `break` and `continue` of an `?else:` block.
fn run4() -> int:
    xs := []int{}
    for 0..5 |i|:
        xs = xs.appended(pick(i) ?else: break)
    return xs.len()

fn run5() -> int:
    xs := []int{}
    for 0..5 |i|:
        xs = xs.appended(pick(i) ?else: continue)
    return xs.len()

-- A member: the in-place call does not change it when an argument fails.
fn run6(ok bool) -> int:
    s := S{xs=[]int{1}}
    try:
        s.xs = s.xs.appended(may(ok)!)
    else:
        return s.xs.len() + 10
    return s.xs.len()

-- A `return` from an argument, and a `!` that returns from the function.
fn run7(i int) -> int:
    xs := []int{1}
    for 0..3:
        xs = xs.appended(pick(i) ?else: return xs.len() + 10)
    return xs.len()

fn run8(ok bool) -> !int:
    xs := []int{1}
    for 0..3:
        xs = xs.appended(may(ok)!)
    return xs.len()

-- The buffer is still reused where no argument can leave: a local of the `try` body, `!else` with a default value,
-- `!=`, and a statement after the `try`.
fn run9() -> !void:
    xs := []int{1, 2, 3}
    xs = xs.appended(4)
    xs = xs.appended(4)
    try:
        ys := []int{1, 2, 3}
        ys = ys.appended(4)
        ys = ys.appended(4)
        p := as[int] ys.ptr
        ys = ys.removed(may(true)!)
        test.eq(true, p == as[int] ys.ptr)

        q := as[int] xs.ptr
        xs = xs.removed(may(false) !else 0)
        test.eq(true, q == as[int] xs.ptr)
        n := 0
        xs = xs.removed(if (n != 0) 1 else 0)
        test.eq(true, q == as[int] xs.ptr)
        -- A `!` that can fail: a copy.
        xs = xs.removed(may(true)! - 2)
        test.eq(false, q == as[int] xs.ptr)
    else:
        test.fail()
    r := as[int] xs.ptr
    xs = xs.removed(may(true)! - 2)
    test.eq(true, r == as[int] xs.ptr)
    test.eq(1, xs.len())

-- Managed elements: the handler reads the list that the failed statement left.
fn name(ok bool) -> !str:
    if !ok:
        return error.Nope
    return 'b'.repeat(3)

fn run10(ok bool) -> str:
    strs := []str{'a'.repeat(3)}
    try:
        strs = strs.appended(name(true)!)
        strs = strs.appended(name(ok)!)
    else:
        return strs[strs.len() - 1] + '!'
    return strs[strs.len() - 1]

test.eq(2, run(true))
test.eq(11, run(false))
test.eq(7, run2(true))
test.eq(14, run2(false))
test.eq(2, run3(true)!)
test.eq(-1, run3(false) !else -1)
test.eq(2, run4())
test.eq(4, run5())
test.eq(2, run6(true))
test.eq(11, run6(false))
test.eq(4, run7(0))
test.eq(11, run7(2))
test.eq(4, run8(true)!)
test.eq(-1, run8(false) !else -1)
run9()!
test.eq('bbb', run10(true))
test.eq('bbb!', run10(false))

--cytest: pass
