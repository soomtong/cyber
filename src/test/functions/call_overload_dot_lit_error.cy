-- No overload takes the enum literal: the error is the one of the first overload.
type Color enum:
    case red
    case blue

fn k(c Color) -> str:
    return 'color'
fn k(x int) -> str:
    return 'int'

print(k(.green))

--cytest: error
--CompileError: Could not infer `Color` enum case from `green`.
--
--@MainPath():11:9:
--print(k(.green))
--        ^~~~~~
--
