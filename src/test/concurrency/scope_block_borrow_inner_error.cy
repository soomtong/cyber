fn add(out &int, n int):
    out.* += n

scope |s|:
    inner := 0
    s.start(add, {&inner, 1})

--cytest: error
--CompileError: A fiber of the `scope` block can not borrow `inner`: it is declared inside the block and is gone before the fibers are done. Declare it before the block.
--
--@MainPath():6:19:
--    s.start(add, {&inner, 1})
--                  ^~~~~~
--