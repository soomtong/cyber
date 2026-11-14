a := 123
fn foo():
    a = 234

--cytest: error
--CompileError: Undeclared variable `a`. To declare a new variable, write `a := ...`.
--
--@MainPath():3:5:
--    a = 234
--    ^
--