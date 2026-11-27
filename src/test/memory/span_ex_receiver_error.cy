-- A `&&T` method on an element of a span can resize what another borrow points into.
fn grow(xs [&][]int, inner [&]int):
    for 0..1000 |i|:
        xs[0].append(i)
    print(inner[0])

lists := [][]int{{1, 2, 3}}
grow(lists.span(), lists[0].span())

--cytest: error
--CompileError: Cannot borrow exclusively through a span `[&]T`, which is a shared borrow of its elements. Take the slice as `&&[]T`.
--
--@MainPath():4:9:
--        xs[0].append(i)
--        ^~~~~
--
