type F = fn() -> int

type H:
    cb OpaqueFunc[F]

x := 1
bx := &x
h := H{cb=fn() -> int => bx.* + 1}
begin:
    z := 4
    bz := &z
    h.cb = fn() -> int => bz.* + 1
print(h.cb())

--cytest: error
--CompileError: `h` can not outlive `z`.
--
--@MainPath():12:17:
--    h.cb = fn() -> int => bz.* + 1
--                ^~~~~~~~~~~~~~~~~~
--
