-- A borrow that is stored through a borrow (`pp.* = &z`) can not outlive what it borrows. The message names the local
-- that the borrow is rooted at.
fn run():
    y := 5
    var r &int = &y
    pp := &r
    if true:
        z := 42
        pp.* = &z
    print(r.*)

run()

--cytest: error
--CompileError: `y` can not outlive `z`.
--
--@MainPath():9:16:
--        pp.* = &z
--               ^~
--
