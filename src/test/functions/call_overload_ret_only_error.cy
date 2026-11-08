fn f(a int) -> int:
    return a

fn f(a int) -> float:
    return 1.0

print(f(1))

--cytest: error
--CompileError: `f` has already been declared with the same parameters. Overloads must differ in their parameter types, not only in the return type.
--
--@MainPath():4:1:
--fn f(a int) -> float:
--^~~~~~~~~~~~~~~~~~~~~
--
