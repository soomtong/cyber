-- The default of `?else` is a branch of the result.
fn g(scope p &[]int, k int) -> scope &int:
    y := 1
    var o ?&int = none
    if k == 1:
        o = &p[0]
    return o ?else &y

a := []int{1, 2}
print(g(&a, 2).*)

--cytest: error
--CompileError: Expected to return a borrow from the same scope as `p`.
--
--@MainPath():7:5:
--    return o ?else &y
--    ^~~~~~~~~~~~~~~~~
--