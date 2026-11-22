type Ix:
    v int

fn (&&Ix) `!`() -> bool:
    self.v += 1
    return true

x := Ix{v = 1}
b := &x
print(!b)

--cytest: error
--CompileError: Expected argument `&>Ix`, found `&Ix`, when calling `fn !(&>Ix) -> bool`.
--
--@MainPath():10:8:
--print(!b)
--       ^
--
