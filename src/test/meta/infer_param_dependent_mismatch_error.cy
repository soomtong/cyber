type Pair[T Any, U Any]:
    a T
    b U

fn second(x %T, p Pair[T, %U]) -> U:
    return p.b

print(second(1, Pair[str, str]{a='a', b='x'}))

--cytest: error
--CompileError: Expected type `Pair[int, str]`. Found `Pair[str, str]`.
--
--@MainPath():8:17:
--print(second(1, Pair[str, str]{a='a', b='x'}))
--                ^~~~~~~~~~~~~~~~~~~~~~~~~~~~
--