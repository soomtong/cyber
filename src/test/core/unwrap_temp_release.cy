use t 'test'

-- A payload taken out of a temporary option or result with `.?` or `!` is a new value.
-- When `==` or `for` borrows it, a temp holds it and releases it at the end of the statement
-- (the runner checks that nothing leaks).
fn opt_str() -> ?str:
    return 'ab'.repeat(20)

fn opt_slice() -> ?[]str:
    return []str{'ab'.repeat(5), 'cd'.repeat(5)}

fn res_str() -> !str:
    return 'ab'.repeat(20)

fn res_slice() -> ![]str:
    return []str{'ab'.repeat(5), 'cd'.repeat(5)}

fn run() -> !void:
    t.eq(false, opt_str().? == 'x')
    t.eq(true, 'x' != opt_str().?)
    t.eq(false, res_str()! == 'x')
    n := 0
    for opt_slice().? |s|:
        n += s.len()
    for res_slice()! |i, s|:
        n += i + s.len()
    t.eq(41, n)
    t.eq(40, opt_str().?.len())

run()!

--cytest: pass
