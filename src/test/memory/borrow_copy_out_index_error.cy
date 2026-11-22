-- An element that is read by a computed index can not outlive what the vector borrows.
fn run():
    x := 7
    var r &int = &x
    if true:
        y := 5
        xs := [2]&int{&x, &y}
        var i int = 1
        r = xs[i]
    print(r.*)

run()

--cytest: error
--CompileError: `r` can not outlive `y`.
--
--@MainPath():9:13:
--        r = xs[i]
--            ^~~~~
--
