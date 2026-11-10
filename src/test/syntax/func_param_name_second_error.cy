fn foo(a int, 1):
    pass

--cytest: error
--ParseError: Expected parameter name.
--
--@MainPath():1:15:
--fn foo(a int, 1):
--              ^
--
