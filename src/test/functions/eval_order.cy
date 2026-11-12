use test

-- Operands are evaluated left to right, also when a later operand needs a temporary (F-98).
log := ^ArrayStore[str]{}
type A:
    n int
fn mk(log ^ArrayStore[str], n int) -> A:
    log << 'mk%{n}'
    return A{n=n}
fn (&A) get(log ^ArrayStore[str]) -> int:
    log << 'get%{self.n}'
    return self.n
fn word(log ^ArrayStore[str], s str) -> str:
    log << 'word-%{s}'
    return s + '!'
fn fail(log ^ArrayStore[str]) -> !str:
    log << 'fail'
    return error.Boom
fn pick(a %T, b T) -> T:
    return b
-- An owned value that waits for a later operand is destructed when that operand returns early.
fn early(log ^ArrayStore[str]) -> !str:
    return word(log, 'a') + fail(log)!
r := early(log)
test.eq(r.unwrap_error(), error.Boom)
test.eq(log.len(), 2)
test.eq(log[0], 'word-a')
test.eq(log[1], 'fail')
-- Generic call.
log = ^ArrayStore[str]{}
_ = pick(mk(log, 1).get(log), mk(log, 2).get(log))
test.eq(log[0] + log[1] + log[2] + log[3], 'mk1get1mk2get2')
-- Overloaded callee: a candidate that does not match is retried.
fn over(a int, b str) -> int:
    return a
fn over(a int, b int) -> int:
    return a + b
log = ^ArrayStore[str]{}
x := mk(log, 1).get(log) + over(mk(log, 2).get(log), mk(log, 3).get(log))
test.eq(x, 6)
out := ''
for 0..log.len() |i|:
    out += log[i]
test.eq(out, 'mk1get1mk2get2mk3get3')

fn say(log ^ArrayStore[str], n int) -> int:
    log << 'say%{n}'
    return n
fn joined(log ^ArrayStore[str]) -> str:
    res := ''
    for 0..log.len() |i|:
        res += log[i]
    return res
fn add(a int, b int) -> int:
    return a + b
type P:
    a int
    b int

-- Binary operator with a plain call on the left.
log = ^ArrayStore[str]{}
test.eq(say(log, 1) + mk(log, 2).get(log), 3)
test.eq(joined(log), 'say1mk2get2')
log = ^ArrayStore[str]{}
test.eq(say(log, 1) < mk(log, 2).get(log), true)
test.eq(joined(log), 'say1mk2get2')

-- Call arguments, nested.
log = ^ArrayStore[str]{}
test.eq(add(say(log, 1), add(say(log, 2), mk(log, 3).get(log))), 6)
test.eq(joined(log), 'say1say2mk3get3')

-- Array, struct and string template.
log = ^ArrayStore[str]{}
arr := []int{say(log, 1), mk(log, 2).get(log)}
test.eq(arr[0] + arr[1], 3)
test.eq(joined(log), 'say1mk2get2')
log = ^ArrayStore[str]{}
p := P{a=say(log, 1), b=mk(log, 2).get(log)}
test.eq(p.a + p.b, 3)
test.eq(joined(log), 'say1mk2get2')
log = ^ArrayStore[str]{}
test.eq('%{say(log, 1)}-%{mk(log, 2).get(log)}', '1-2')
test.eq(joined(log), 'say1mk2get2')

-- Managed values on the left.
log = ^ArrayStore[str]{}
test.eq(word(log, 'a') + word(log, 'b') + str(mk(log, 3).get(log)), 'a!b!3')
test.eq(joined(log), 'word-aword-bmk3get3')

--cytest: pass