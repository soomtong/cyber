auto x: float

--cytest: error
--ParseError: Cyber has no `auto`. Declare with `var x float = value`.
--
--@MainPath():1:1:
--auto x: float
--^
--
