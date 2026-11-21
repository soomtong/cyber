foo()

fn foo() -> int:
    return 123

--cytest: error
--CompileError: Expected assignment to a variable or placeholder for `int`. Write `_ = foo()` to drop the value.
--
--@MainPath():1:1:
--foo()
--^~~~~
--