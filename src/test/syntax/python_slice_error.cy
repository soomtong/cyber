-- Python's slice says the Cyber form.
s := 'abcdef'
print(s[2:])

--cytest: error
--ParseError: A slice is written `s[..3]`, `s[2..]` or `s[1..3]`, not `s[:3]`.
--
--@MainPath():3:10:
--print(s[2:])
--         ^
--