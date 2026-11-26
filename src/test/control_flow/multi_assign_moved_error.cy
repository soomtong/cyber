xs := Array[int]{1}
ys := Array[int]{2}
a, b := xs, xs
print(a.len())

--cytest: error
--CompileError: `xs` was moved at 3:9. Borrow it with `&xs` or clone it to use it here.
--
--@MainPath():3:13:
--a, b := xs, xs
--            ^~
--