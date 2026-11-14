fn f():
    in_s str = ''
    print(in_s)
f()

--cytest: error
--ParseError: To declare a typed variable, write `var in_s str = ''`.
--
--@MainPath():2:5:
--    in_s str = ''
--    ^
--