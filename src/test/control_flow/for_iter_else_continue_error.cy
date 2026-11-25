type Src:
    n int

fn (&Src) iterator() -> int:
    return 0

fn (&Src) next(i &int) -> !?int:
    return error.Bad

for Src{n=0} |x|:
    print(x)
else:
    continue

--cytest: error
--CompileError: `continue` can not go on with an iterator that failed. The `else` block of `for` ends the loop: leave out `continue`.
--
--@MainPath():13:5:
--    continue
--    ^~~~~~~~
--