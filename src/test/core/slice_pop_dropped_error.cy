-- A dropped value says the statement to write.
xs := []str{'a', 'b'}
while xs.len() > 1:
    xs.pop()
print(xs.len())

--cytest: error
--CompileError: Expected assignment to a variable or placeholder for `?str`. Write `_ = xs.pop()` to drop the value.
--
--@MainPath():4:5:
--    xs.pop()
--    ^~~~~~~~
--