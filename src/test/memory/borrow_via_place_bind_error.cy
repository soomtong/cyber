-- A copy that is read through a borrow of a container that holds a borrow of a place in another container can not
-- outlive the container.
type W:
    x int
    q &int

type H:
    a &int
    b &int

fn run():
    y := 5
    var r &int = &y
    if true:
        w := W{x=42, q=&y}
        h := H{a=&y, b=&w.x}
        hr := &h
        r2 := hr.b
        r = r2
    print(r.*)

run()

--cytest: error
--CompileError: `r` can not outlive `h`.
--
--@MainPath():19:13:
--        r = r2
--            ^~
--
