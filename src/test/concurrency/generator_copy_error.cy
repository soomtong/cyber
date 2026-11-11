#[generator]
fn gen() -> int:
    yield 1
x := gen().*

--cytest: error
--CompileError: Cannot copy `Generator[fn() -> int]`, type implements `NoCopy`.
--
--@MainPath():4:6:
--x := gen().*
--     ^~~~~~~
--
