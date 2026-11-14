x := 1
if x == 1:
    # note here
    print(x)

--cytest: error
--ParseError: A comment starts with `--`, not `#`.
--
--@MainPath():3:5:
--    # note here
--    ^
--
