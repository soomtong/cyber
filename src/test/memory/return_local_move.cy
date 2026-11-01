use t 'test'

-- Returning a local moves it. A type without `@copy` is copied bitwise, so copying the local
-- ran its `@deinit` at the return and again in the caller.
type R:
    count ^int

fn (&R) @deinit():
    self.count.* += 1

type W:
    r R
    n int

fn ret_local(count ^int) -> R:
    r := R{count = count}
    return r

fn ret_nested(count ^int) -> W:
    w := W{r = R{count = count}, n = 0}
    w.n += 1
    return w

fn ret_branch(count ^int, early bool) -> R:
    r := R{count = count}
    if early:
        return r
    t.eq(0, r.count.*)
    return r

fn ret_param(r R) -> R:
    return r

fn ret_option(count ^int) -> ?R:
    r := R{count = count}
    return r

fn ret_result(count ^int) -> !R:
    r := R{count = count}
    return r

count := ^int(0)

do_local(count)
t.eq(1, count.*)
count.* = 0
do_nested(count)
t.eq(1, count.*)
count.* = 0
do_branch(count, true)
t.eq(1, count.*)
count.* = 0
do_branch(count, false)
t.eq(1, count.*)
count.* = 0
do_param(count)
t.eq(1, count.*)
count.* = 0
do_option(count)
t.eq(1, count.*)
count.* = 0
do_result(count)
t.eq(1, count.*)

fn do_local(count ^int):
    r := ret_local(count)
    t.eq(0, count.*)

fn do_nested(count ^int):
    w := ret_nested(count)
    t.eq(0, count.*)
    t.eq(1, w.n)

fn do_branch(count ^int, early bool):
    r := ret_branch(count, early)
    t.eq(0, count.*)

fn do_param(count ^int):
    r := ret_param(R{count = count})
    t.eq(0, count.*)

fn do_option(count ^int):
    r := ret_option(count)
    t.eq(0, count.*)

fn do_result(count ^int):
    r := ret_result(count)
    t.eq(0, count.*)

--cytest: pass
