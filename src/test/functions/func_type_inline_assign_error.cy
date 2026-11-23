type StrFn = fn(str) -> str

fn ident(s str) -> str:
    return s

var a StrFn = ident
var f fn(int) -> int = a

--cytest: error
--CompileError: Expected type `fn(int) -> int`, got `fn(str) -> str`.
--
--@MainPath():7:24:
--var f fn(int) -> int = a
--                       ^
--