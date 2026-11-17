#[extern='abs']
fn c_abs(a int) -> int
print(c_abs(-3))

--cytest: error
--CompileError: An `#[extern]` function needs the `c` module. Add `use c`.
--
--@MainPath():1:1:
--#[extern='abs']
--^~~~~~~~~~~~~~~
--
