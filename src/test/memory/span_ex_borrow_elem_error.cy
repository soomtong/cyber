fn first(xs [&][]int) -> int:
    r := &&xs[0]
    return r.len()

lists := [][]int{{1}}
print(first(lists.span()))

--cytest: error
--CompileError: Cannot borrow exclusively through a span `[&]T`, which is a shared borrow of its elements. Take the slice as `&&[]T`.
--
--@MainPath():2:10:
--    r := &&xs[0]
--         ^~~~~~~
--
