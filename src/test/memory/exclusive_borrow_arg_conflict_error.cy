fn grow(arr &&Array[int], elem &int):
    arr.append(elem.*)

a := Array[int]{1, 2, 3}
grow(&&a, &a[0])

--cytest: error
--CompileError: Cannot pass an exclusive borrow of `a` with another argument that borrows `a`.
--
--@MainPath():5:6:
--grow(&&a, &a[0])
--     ^~~
--
