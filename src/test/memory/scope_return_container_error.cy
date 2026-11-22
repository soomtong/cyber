-- A borrow container is checked like `&T`.
type Holder:
    r &int

fn g(scope p &[]int, k int) -> scope Holder:
    y := 1
    return Holder{r=&y}

a := []int{1, 2}
print(g(&a, 2).r.*)

--cytest: error
--CompileError: Expected to return a borrow from the same scope as `p`.
--
--@MainPath():7:5:
--    return Holder{r=&y}
--    ^~~~~~~~~~~~~~~~~~~
--