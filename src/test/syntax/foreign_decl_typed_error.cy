let x: int = 1
print(x)

--cytest: error
--ParseError: Cyber has no `let`. Declare with `var x int = 1`.
--
--@MainPath():1:1:
--let x: int = 1
--^
--
