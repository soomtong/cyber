s := 'a\xZZb'

--cytest: error
--CompileError: Invalid escape sequence `\xZZ`. `\x` takes two hex digits: `\x41`. Write `\\` for a backslash.
--
--@MainPath():1:6:
--s := 'a\xZZb'
--     ^~~~~~~~
--