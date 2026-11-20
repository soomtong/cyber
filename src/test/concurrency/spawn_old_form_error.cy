fn f(a int) -> int:
    return a

x := spawn(f, {1})

--cytest: error
--ParseError: Expected a function call after `spawn`: `spawn f(a, b)`. The form `spawn(f, {a, b})` was replaced.
--
--@MainPath():4:6:
--x := spawn(f, {1})
--     ^
--