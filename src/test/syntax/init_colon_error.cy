m := Map[str, int]{'app': 7}

--cytest: error
--ParseError: Expected `=` between a key and a value. An initializer uses `key=value`, not `key: value`.
--
--@MainPath():1:25:
--m := Map[str, int]{'app': 7}
--                        ^
--