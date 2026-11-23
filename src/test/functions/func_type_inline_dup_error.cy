type IntFn = fn(int) -> int

fn over(f IntFn) -> int:
    return 1

-- The inline type is the type of the alias.
fn over(f fn(int) -> int) -> int:
    return 2

--cytest: error
--CompileError: `over` has already been declared with the same function signature.
--
--@MainPath():7:1:
--fn over(f fn(int) -> int) -> int:
--^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--