-- A `const` template parameter type the instance cache can not hash or compare is a
-- compile error at the parameter, not a compiler panic (F-28).
type Scale[const F float]:
    v int

s := Scale[1.5]{v=1}

--cytest: error
--CompileError: Unsupported `const` parameter type `float`. A `const` template parameter can be a type, an integer, a `bool`, an enum, an `EvalStr`, or a function symbol.
--
--@MainPath():3:20:
--type Scale[const F float]:
--                   ^~~~~
--