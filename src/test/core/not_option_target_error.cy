var o ?bool = true
var a ?bool = !o

--cytest: error
--CompileError: `not` takes a `bool`. Found `?bool`. For an option, compare with `none` (`x == none`), unwrap it with `if x |v|:`, or give a default with `?else`.
--
--@MainPath():2:15:
--var a ?bool = !o
--              ^~
--
