-- A returned local that borrows from one of two owners borrows from both.
fn g(scope p &[]int, k int) -> scope &int:
    y := 1
    r := if (k == 1) &y else &p[0]
    return r

a := []int{1, 2}
print(g(&a, 2).*)

--cytest: error
--CompileError: Expected to return a borrow from the same scope as `p`.
--
--@MainPath():5:5:
--    return r
--    ^~~~~~~~
--