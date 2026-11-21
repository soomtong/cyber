-- A loop that does not use its value has no `|_|`.
for 0..2 |_|:
    print('x')
print('end')

--cytest: error
--ParseError: A loop that does not use its value is written `for 0..n:` or `for xs:`. `|_|` is not allowed.
--
--@MainPath():2:11:
--for 0..2 |_|:
--          ^
--