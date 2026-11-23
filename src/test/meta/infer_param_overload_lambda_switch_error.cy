-- A case of a `switch` expression is compared like a branch of an `if` expression.
fn pick(x int, f fn(int) -> str) -> str:
    return f(x)
fn pick(x int, f fn(int) -> int) -> str:
    return 'i'

r := pick(1, |x|):
    return switch x:
        case 1 => 'one'
        else => 2.5
print(r)

--cytest: error
--CompileError: Expected type `str`, got `float`.
--
--@MainPath():10:17:
--        else => 2.5
--                ^~~
--
