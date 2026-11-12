fn add(out &int, n int):
    out.* += n

total := 0
s := Scope.new()
s.start(add, {&total, 1})

--cytest: error
--CompileError: Cannot borrow a stack value across fibers. The parameter type is `&int`. Only `s.start(func, {...})` on the name of a `scope |s|:` block takes a borrow. Use `^T`.
--
--@MainPath():6:1:
--s.start(add, {&total, 1})
--^~~~~~~~~~~~~~~~~~~~~~~~~
--