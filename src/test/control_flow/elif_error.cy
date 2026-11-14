a := 1
if a == 1:
    print(1)
elif a == 2:
    print(2)

--cytest: error
--ParseError: `elif` is not a keyword. Write `else cond:`, not `elif cond:`.
--
--@MainPath():4:1:
--elif a == 2:
--^
--
