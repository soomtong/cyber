type Pair[T Any, U Any]:
    a T
    b U

fn second(x %T, p Pair[T, %U]) -> U:
    return p.b

const r = second(1, Pair[int, str]{a=1, b='x'})
print(r)

--cytest: error
--CompileError: Can not infer the template parameter `U` from the argument for `p`. Declare it as its own parameter (`%U type`) and pass the type in the call.
--
--@MainPath():8:21:
--const r = second(1, Pair[int, str]{a=1, b='x'})
--                    ^~~~~~~~~~~~~~~~~~~~~~~~~~
--
