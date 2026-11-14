n := 'x'
print('%{'L%{n}'.len()}')

--cytest: error
--TokenError: An interpolated string can not contain another interpolated string. Assign the inner string to a variable first.
--
--@MainPath():2:12:
--print('%{'L%{n}'.len()}')
--           ^
--
