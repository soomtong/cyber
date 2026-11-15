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

-- `!else` moves the payload out of a returned result like `!` does, so a `NoCopy` payload unwraps (F-145).
-- A result held in a variable is still copied.
fn res_map(fail bool) -> !Map[str, int]:
    if fail:
        return error.Fail
    var m Map[str, int] = {}
    m['a'] = 1
    return m

global deinits int = 0

type Res:
    n int

fn (&Res) @deinit():
    deinits += 1

fn res_res(n int) -> !Res:
    if n < 0:
        return error.Neg
    return Res{n=n}

fn run_else() -> !void:
    a := res_map(false) !else Map[str, int]{}
    t.eq(1, a['a'])
    b := res_map(true) !else Map[str, int]{}
    t.eq(0, b.size())
    c := res_map(false) !else |err|:
        return err
    t.eq(1, c['a'])
    r := res_res(1) !else Res{n=9}
    t.eq(1, r.n)
    var held !int = 5
    t.eq(5, held !else 0)
    t.eq(5, held !else 0)
    q := res_res(-1) !else |err|:
        t.eq(error.Neg, err)
        return
    t.fail()

run_else()!
t.eq(1, deinits)

--cytest: pass
