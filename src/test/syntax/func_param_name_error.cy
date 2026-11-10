fn foo(&&self):
    pass

--cytest: error
--ParseError: Expected parameter name.
--
--@MainPath():1:8:
--fn foo(&&self):
--       ^
--
