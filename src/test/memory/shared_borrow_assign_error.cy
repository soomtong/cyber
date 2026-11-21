-- A managed value is not replaced through a shared borrow: the old value is freed under another borrow.
type Foo:
    xs []int

fn (&Foo) reset():
    self.xs = {7}

f := Foo{xs={1, 2, 3}}
s := &f.xs[0]
f.reset()
print(s.*)

--cytest: error
--CompileError: Cannot replace a managed value through a shared borrow. Declare the borrow as `&&T`.
--
--@MainPath():6:5:
--    self.xs = {7}
--    ^~~~~~~~~~~~~
--