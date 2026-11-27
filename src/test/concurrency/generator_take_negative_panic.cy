generator fn three() -> int:
    yield 1
    yield 2
    yield 3

_ = three().take(-1)

--cytest: panic
--panic: Expected a count of 0 or more, found -1.
--
--[trace]
--core:5003:9 Generator.take:
--        panic('Expected a count of 0 or more, found %{n}.')
--        ^
--@MainPath():6:5 main:
--_ = three().take(-1)
--    ^
--