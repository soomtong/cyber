-- Each `break` of a loop that follows a move of an outer local has to follow the same moves.
type R struct:
    with NoCopy
    id int

fn take(r R):
    pass

a := R{id=1}
b := R{id=2}
for 0..3 |i|:
    if i == 1:
        take(a)
        break
    if i == 2:
        take(b)
        break

--cytest: error
--CompileError: Cannot leave the loop here: `a` is moved before only one of this `break` and the `break` at 14:9. Each `break` that follows a move of a variable declared outside the loop has to follow the same moves. Move `a` after the loop instead.
--
--@MainPath():17:9:
--        break
--        ^~~~~
--