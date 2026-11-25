type Src:
    n int

fn (&Src) iterator() -> int:
    return 0

fn (&Src) next(i &int) -> !?int:
    return none

for Src{n=0} |x|:
    print(x)

--cytest: error
--CompileError: The iterator can fail: `next` returns `!?int`. Handle its error with an `else |err|:` block after the body of `for`.
--
--@MainPath():10:5:
--for Src{n=0} |x|:
--    ^~~~~~~~
--