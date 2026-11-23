-- `fn(...)` in an expression is a lambda unless `)`, `]`, `,` or `}` follows.
f := fn(a int) -> int
print(f(1))

--cytest: error
--ParseError: Expected colon.
--
--@MainPath():2:22:
--f := fn(a int) -> int
--                     ^
--