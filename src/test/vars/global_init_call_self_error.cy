global a []int = foo()

fn foo() -> []int:
    a = []int{1, 2, 3}
    return []int{4}

--cytest: error
--CompileError: The initializer of `a` can reach `foo`, which accesses `a` before it is initialized.
--
--@MainPath():1:18:
--global a []int = foo()
--                 ^~~~~
--
