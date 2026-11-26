use test

-- `?else` and `!else` take one `return`, `break` or `continue` on the same line, without `:`.
fn half(o ?int) -> ?int:
    n := o ?else return none
    return n / 2
test.eq(2, half(4).?)
test.eq(true, half(none) == none)

fn parse_or(s str, d int) -> int:
    n := int.parse(s) !else return d
    return n
test.eq(12, parse_or('12', -1))
test.eq(-1, parse_or('x', -1))

fn doubled(s str) -> !int:
    n := int.parse(s) !else |err| return err
    return n * 2
test.eq(10, doubled('5')!)
test.eq(error.InvalidCharacter, doubled('x').unwrap_error())

total := 0
for []?int{1, none, 3} |o|:
    v := o ?else continue
    total += v
test.eq(4, total)

seen := 0
for []?int{1, none, 3} |o|:
    v := o ?else break
    seen += v
test.eq(1, seen)

--cytest: pass
