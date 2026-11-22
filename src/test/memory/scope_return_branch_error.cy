-- Every branch of the result is a borrow from the `scope` parameter, whatever its order.
fn g(scope p &[]int, k int) -> scope &int:
    y := 1
    return if (k == 1) &p[0] else &y

a := []int{1, 2}
print(g(&a, 2).*)

--cytest: error
--CompileError: Expected to return a borrow from the same scope as `p`.
--
--@MainPath():4:5:
--    return if (k == 1) &p[0] else &y
--    ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--