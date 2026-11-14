use test

-- A value given with `move x` is not destructed by `x` anymore. When the fiber is cancelled in a later operand,
-- before the consumer took it, the cancel pad destructs it.
type Res:
    id int
global dropped int = 0
fn (&Res) @deinit():
    dropped += 1
fn sus() -> int:
    suspend
    return 0
fn susr() -> Res:
    suspend
    return Res{id=9}
fn take2(a Res, b int) -> int:
    return a.id + b
type Pair:
    a Res
    b int

fn in_call():
    x := Res{id=1}
    _ = take2(move x, sus())
fn in_list():
    x := Res{id=1}
    _ = {move x, susr()}
fn in_struct():
    x := Res{id=1}
    _ = Pair{a=move x, b=sus()}
fn in_lambda():
    x := Res{id=1}
    f := fn(a Res, b int) -> int:
        return a.id + b
    _ = f(move x, sus())

fn check(fb Fiber):
    dropped = 0
    test.eq(fb.resume(), .suspended)
    test.eq(fb.cancel(), true)
    test.eq(dropped, 1)
check(fiber in_call())
check(fiber in_list())
check(fiber in_struct())
check(fiber in_lambda())

-- Without a cancel, a moved reference is released once its consumer is done with it.
type R:
    id int
global released int = 0
fn (&R) @deinit():
    released += 1
fn take(r ^R) -> int:
    return r.id
fn moves():
    a := ^R{id=1}
    test.eq(take(move a), 1)
    b := ^R{id=2}
    c := move b
    test.eq(c.id, 2)
moves()
test.eq(released, 2)

--cytest: pass
