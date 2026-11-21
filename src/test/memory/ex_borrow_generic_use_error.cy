-- An exclusive borrow that a parameter holds is also checked when it is passed to a function template.
fn grow(x %T, a &&Array[T]):
    for 0..1000 |i|:
        a.append(x)

fn foo(a &&Array[int]):
    s := &a[0]
    grow(5, a)
    print(s.*)

xs := Array[int]{1, 2, 3}
foo(&&xs)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():8:13:
--    grow(5, a)
--            ^
--
