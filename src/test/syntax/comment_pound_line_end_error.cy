x := 1 # comment

--cytest: error
--ParseError: A comment starts with `--`, not `#`.
--
--@MainPath():1:8:
--x := 1 # comment
--       ^
--
