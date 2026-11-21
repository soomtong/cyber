-- The element that `@index_addr` returns is reached through the borrow of its receiver.
type Foo:
    xs []str

fn set(f &Foo):
    f.xs[0] = 'a long string that is on the heap %{f.xs.len()}'

f := Foo{xs={'first string value on heap %{1}', 'b'}}
s := &f.xs[0]
set(&f)
print(s.*)

--cytest: error
--CompileError: Cannot replace a managed value through a shared borrow. Declare the borrow as `&&T`.
--
--@MainPath():6:5:
--    f.xs[0] = 'a long string that is on the heap %{f.xs.len()}'
--    ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--