use t 'test'

-- An iterator whose `next` returns `!?T`: it ends with `none`, or fails with an error.
type Src:
    fail_at int

fn (&Src) iterator() -> int:
    return 0

fn (&Src) next(i &int) -> !?int:
    i.* += 1
    if i.* == self.fail_at:
        return error.Bad
    if i.* > 4:
        return none
    return i.*

-- The error ends the loop in the `else` block.
var seen []int = {}
var failed ?error = none
for Src{fail_at=3} |x|:
    seen += x
else |err|:
    failed = err
t.eq(2, seen.len())
t.eq(error.Bad, failed.?)

-- Without an error the `else` block does not run. The index works as usual.
sum := 0
for Src{fail_at=0} |i, x|:
    sum += i * 10 + x
else:
    sum = -1
t.eq(70, sum)

-- `break` in the body, and `return` and `break` in the `else` block.
fn first_even(s Src) -> !int:
    for s |x|:
        if x % 2 == 0:
            return x
    else |err|:
        return err
    return -1
t.eq(2, first_even(Src{fail_at=9})!)
t.eq(error.Bad, first_even(Src{fail_at=2}).unwrap_error())

-- A loop in the `else` block may use `continue`, and the block may reach its end.
inner := 0
for Src{fail_at=1} |x|:
    inner = -1
else:
    for {1, 2, 3} |y|:
        if y == 2:
            continue
        inner += y
t.eq(4, inner)

--cytest: pass
