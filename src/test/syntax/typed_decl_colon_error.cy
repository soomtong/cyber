fn f():
    q: byte = 0
    print(q)
f()

--cytest: error
--ParseError: To declare a typed variable, write `var q byte = 0` or `q := byte(0)`.
--
--@MainPath():2:5:
--    q: byte = 0
--    ^
--