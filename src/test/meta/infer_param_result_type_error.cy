-- `!%U` is matched with a result type. A function that can not fail does not bind `U`.
fn conv(x %T, f fn(T) -> !%U) -> !U:
    return f(x)

fn plain(s str) -> int:
    return 1

print(conv('1', plain)!)

--cytest: error
--CompileError: Expected template `Result`. Found `Int`.
--
--@MainPath():8:17:
--print(conv('1', plain)!)
--                ^~~~~
--