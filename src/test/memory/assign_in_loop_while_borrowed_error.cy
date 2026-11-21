-- A loop borrows what it iterates until it ends, so the value can not be replaced in the body.
type Foo:
    xs []int

f := Foo{xs={1, 2, 3}}
for f.xs |x|:
    f.xs = {7, 8, 9, 10}
    print(x)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `f`.
--
--@MainPath():7:5:
--    f.xs = {7, 8, 9, 10}
--    ^~~~~~~~~~~~~~~~~~~~
--
