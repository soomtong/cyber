fn f():
    val name = 'a'
    print(name)
f()

--cytest: error
--ParseError: Cyber has no `val`. Declare with `name := 'a'`, or `var name str = 'a'` for a type.
--
--@MainPath():2:5:
--    val name = 'a'
--    ^
--
