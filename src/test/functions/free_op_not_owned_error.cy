type Cents:
    n int

-- Neither `int` nor `float` is declared in this module.
fn `*`(a int, b float) -> float:
    return float(a) * b

--cytest: error
--CompileError: The operator function `*` must take a type declared in this module, so that `a * b` can find it from the type of `a` or `b`.
--
--@MainPath():5:1:
--fn `*`(a int, b float) -> float:
--^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--