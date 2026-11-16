let x = 1
print(x)

--cytest: error
--ParseError: Cyber has no `let`. Declare with `x := 1`, or `var x int = 1` for a type.
--
--@MainPath():1:1:
--let x = 1
--^
--
