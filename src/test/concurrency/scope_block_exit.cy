-- `return`, `break` and `continue` in a `scope` block join the fibers first. An error of a fiber goes on like
-- at a failing `!`.
use test
global dropped int = 0
type Res:
    with NoCopy
    id int
fn (&Res) @deinit():
    dropped += 1
fn fails(e error) -> !void:
    suspend
    return e
fn ok(out &int):
    suspend
    out.* += 1

-- return: joined first, then the result is evaluated
fn ret_val() -> !int:
    total := 0
    scope |s|:
        r := Res{id = 1}
        s.start(ok, {&total})
        s.start(ok, {&total})
        return total * 10
test.eq(ret_val()!, 20)
test.eq(dropped, 1)

-- nested blocks, the inner fiber fails at a return
fn nested(log ^ArrayStore[str]) -> !int:
    total := 0
    scope |a|:
        a.start(ok, {&total})
        scope |b|:
            r := Res{id = 2}
            b.start(fails, {error.Inner})
            return 1
    return 2
dropped = 0
test.eq(nested(^ArrayStore[str]{}).unwrap_error(), error.Inner)
test.eq(dropped, 1)

-- the outer fiber fails at a return from the inner block
fn nested2() -> !int:
    scope |a|:
        a.start(fails, {error.Outer})
        scope |b|:
            return 1
    return 2
test.eq(nested2().unwrap_error(), error.Outer)

-- break and continue: the error leaves the loop's function
fn loop_break() -> !int:
    n := 0
    for 0..5 |i|:
        scope |s|:
            if i == 3:
                s.start(fails, {error.AtThree})
                break
            n += 1
            continue
    return n
test.eq(loop_break().unwrap_error(), error.AtThree)

-- a loop inside the block: break does not join
fn inner_loop() -> !int:
    total := 0
    scope |s|:
        s.start(ok, {&total})
        for 0..3 |i|:
            if i == 1:
                break
        test.eq(total, 0)
    return total
test.eq(inner_loop()!, 1)

-- try: the error of an early exit goes to the else block
fn tried() -> int:
    try:
        scope |s|:
            s.start(fails, {error.T})
            return 1
    else |err|:
        return 2
    return 3
test.eq(tried(), 2)

-- void return and generators
fn void_ret() -> !void:
    scope |s|:
        s.start(fails, {error.V})
        return
test.eq(void_ret().unwrap_error(), error.V)

-- lambda inside the body returns on its own
fn with_lambda() -> !int:
    total := 0
    scope |s|:
        s.start(ok, {&total})
        f := fn(x int) -> int:
            return x + 1
        test.eq(f(1), 2)
        test.eq(total, 0)
    return total
test.eq(with_lambda()!, 1)

--cytest: pass