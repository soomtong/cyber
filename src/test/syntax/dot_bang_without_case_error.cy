line := 'ab#c'
idx := line.index('#')
print(line[idx.!])

--cytest: error
--ParseError: Expected a choice case name after `.!` (`c.!line`). Unwrap an option with `.?`, and an error with `!` after the call (`f()!`).
--
--@MainPath():3:17:
--print(line[idx.!])
--                ^
--
