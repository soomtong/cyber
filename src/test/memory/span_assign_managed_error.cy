-- A span is a shared borrow of its elements. Replacing a managed element frees what another borrow can point into.
fn replace(xs [&][]int, inner [&]int):
    xs[0] = {7, 7, 7}
    print(inner[0])

lists := [][]int{{1, 2, 3}, {4}}
replace(lists.span(), lists[0].span())

--cytest: error
--CompileError: Cannot replace a managed value through a span `[&]T`, which is a shared borrow of its elements. Take the slice as `&&[]T`.
--
--@MainPath():3:5:
--    xs[0] = {7, 7, 7}
--    ^~~~~~~~~~~~~~~~~
--
