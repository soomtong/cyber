use test

-- The branches of an `if` expression and the cases of a `switch` expression move outer locals like the ones of the
-- statements: a local that one branch moved is destructed at the end of the others. The condition of an `if`
-- expression always runs and moves like a part of the statement.

global log str = ''

type R struct:
    with NoCopy
    id int

fn (&R) @deinit():
    log += 'd%{self.id} '

fn take(r R) -> int:
    log += 't%{r.id} '
    return r.id

fn pass2(r R) -> R:
    return r

type K enum:
    case x
    case y
    case z

fn run(n int):
    a := R{id=1}
    b := R{id=2}
    v := if (n == 0) take(a) else take(b)
    log += 'v%{v} '

fn run2(k K):
    a := R{id=1}
    b := R{id=2}
    v := switch k:
        case .x => take(a)
        case .y => take(b)
        else => 0
    log += 'v%{v} '

fn run3(n int):
    a := R{id=1}
    r := if (n == 0) pass2(a) else R{id=5}
    log += 'r%{r.id} '

fn run4(n int):
    a := R{id=1}
    b := R{id=2}
    v := 10 + (if (take(b) == n) take(a) else 0)
    log += 'v%{v} '

fn check(exp str):
    test.eq(exp, log)
    log = ''

run(0)
check('t1 d1 d2 v1 ')
run(1)
check('t2 d2 d1 v2 ')
run2(.x)
check('t1 d1 d2 v1 ')
run2(.y)
check('t2 d2 d1 v2 ')
run2(.z)
check('d1 d2 v0 ')
run3(0)
check('r1 d1 ')
run3(1)
check('d1 r5 d5 ')
run4(1)
check('t2 d2 d1 v10 ')
run4(2)
check('t2 d2 t1 d1 v11 ')

--cytest: pass
