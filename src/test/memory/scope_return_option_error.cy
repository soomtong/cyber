-- `?&T` is checked like `&T`.
fn g(scope p &[]int, k int) -> scope ?&int:
    y := 1
    return &y

a := []int{1, 2}
print(g(&a, 2).?.*)

--cytest: error
--CompileError: Expected to return a borrow from the same scope as `p`.
--
--@MainPath():4:5:
--    return &y
--    ^~~~~~~~~
--