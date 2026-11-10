global a int = foo()
global b int = 123

fn foo() -> int:
    return bar()

fn bar() -> int:
    return b + 1

--cytest: error
--CompileError: The initializer of `a` can reach `bar`, which accesses the global `b`. `b` is initialized after `a`.
--
--@MainPath():1:16:
--global a int = foo()
--               ^~~~~
--
