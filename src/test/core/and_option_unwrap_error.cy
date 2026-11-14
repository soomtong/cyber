t := 'a=1'
ok := true
if ok and t.index('=') |i|:
    print(i)

--cytest: error
--CompileError: Expected type `bool`, got `?int`. An operand of `and` and `or` is not unwrapped: `|v|` applies to the whole condition of the `if`. Unwrap the option in an `if` of its own inside this one: `if x |v|:`, or compare it with `none`.
--
--@MainPath():3:11:
--if ok and t.index('=') |i|:
--          ^~~~~~~~~~~~
--
