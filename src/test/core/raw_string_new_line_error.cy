var fruit = 'app
le'

--cytest: error
--TokenError: Encountered new line in single line literal. Write `\n` for a line break, or use a multi-line string: `'''...'''`.
--
--@MainPath():1:17:
--var fruit = 'app
--                ^
--