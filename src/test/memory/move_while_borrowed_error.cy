-- A managed value can not be moved while a local borrows from it: the new owner can free what the borrow points to.
type Foo:
    xs []int

g := Foo{xs={1, 2, 3}}
s := &g.xs[0]
h := move g
h.xs = {7}
print(s.*)

--cytest: error
--CompileError: Cannot move `g`. There is an active borrow to it.
--
--@MainPath():7:11:
--h := move g
--          ^
--
