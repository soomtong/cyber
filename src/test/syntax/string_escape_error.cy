s := 'TODO\|Todo'

--cytest: error
--CompileError: Invalid escape sequence `\|`. A backslash in a string is followed by one of: n t r 0 a b e \ ' " ` xHH. Write `\\|` for a backslash.
--
--@MainPath():1:6:
--s := 'TODO\|Todo'
--     ^~~~~~~~~~~~
--