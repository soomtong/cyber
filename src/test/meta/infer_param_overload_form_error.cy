fn f(x []%T) -> int:
    return 1
fn f(y []%U) -> int:
    return 2
print(f({1}))

--cytest: error
--CompileError: `f` has already been declared with the same function signature.
--
--@MainPath():3:1:
--fn f(y []%U) -> int:
--^~~~~~~~~~~~~~~~~~~~
--